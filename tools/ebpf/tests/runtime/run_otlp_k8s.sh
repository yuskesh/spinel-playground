#!/usr/bin/env bash
# run_otlp_k8s.sh — E302: cgroup_id -> k8s pod 解決 + span への k8s.* 属性を検証。
#  (1) 解決ロジックの単体テスト (実測 E302 データ: cgroup_id 674->coredns, 592->local-path)
#  (2) 監査 span (E293 型) に k8s.* を載せ、protoc --decode で wire に実 pod 名が出ることを確認
# libbpf 非依存 (span builder 経路)。host で完結。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"

CC="${CC:-clang}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
PROTO_ROOT="${PROTO_ROOT:-${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}}"   # Spinel Extended: OTEL_PROTO_DIR names the user-local pin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[k8s] (1) cgroup_id -> pod 解決の単体テスト"
"$CC" -O2 -Wall -Wextra -I "$OTLP" \
  tests/runtime/otlp_k8s_test.c "$OTLP/otlp_k8s.c" -o "$TMP/k8s"
"$TMP/k8s"

echo "[k8s] (2) 監査 span に k8s.* を載せて OTLP protobuf 符号化 + wire decode"
PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_k8s_span_test.c \
  "$OTLP/otlp_k8s.c" "$OTLP/otlp_traces.c" "$OTLP/otlp_json.c" "$OTLP/otlp_http.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/span"
"$TMP/span" > "$TMP/span.pb"
echo "  span protobuf bytes: $(wc -c < "$TMP/span.pb")"

otlp_decode "opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest" \
  "opentelemetry/proto/collector/trace/v1/trace_service.proto" "$TMP/span.pb" "$TMP/span.txt"
echo "----- wire-decoded span (protoc) -----"; sed -n '1,120p' "$TMP/span.txt"; echo "--------------------------------------"

# semconv k8s.* が実 pod 名で wire に乗っているか
otlp_assert "$TMP/span.txt" 'key: "k8s.pod.name"'
otlp_assert "$TMP/span.txt" 'string_value: "coredns-ccb96694c-5kpb7"'
otlp_assert "$TMP/span.txt" 'key: "k8s.namespace.name"'
otlp_assert "$TMP/span.txt" 'string_value: "kube-system"'
otlp_assert "$TMP/span.txt" 'key: "k8s.pod.uid"'
otlp_assert "$TMP/span.txt" 'key: "k8s.container.name"'
# 既存の監査属性も同居 (E293 型 file 監査 + deny)
otlp_assert "$TMP/span.txt" 'key: "file.path"'
otlp_assert "$TMP/span.txt" 'string_value: "/etc/shadow"'
otlp_assert "$TMP/span.txt" 'key: "process.executable.name"'
otlp_assert "$TMP/span.txt" 'key: "verdict"'

otlp_done "k8s pod correlation span (k8s.pod.name=coredns rides the wire)"
