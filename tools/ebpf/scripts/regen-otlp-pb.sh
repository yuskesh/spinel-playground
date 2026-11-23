#!/usr/bin/env bash
#
# regen-otlp-pb.sh — OTLP protobuf の nanopb C エンコーダを再生成する (ADR-012 / P003 S0)
#
# opentelemetry-proto (third_party) の .proto から nanopb で *.pb.{c,h} を生成し
# src/runtime/otlp/pb/ に出力する。生成物は commit する (移植可能・再現可能)。
#
# ホスト protoc とユーザ環境の python-protobuf が major 不一致になりがちなため
# (例: homebrew protoc 35 ↔ conda protobuf 6.x)、隔離 venv に grpcio-tools を入れ
# (protoc + protobuf がペアでバンドルされ整合)、vendored nanopb generator を
# その venv 経由で回す。ユーザの既存 python env は汚さない。
#
# pin: nanopb 0.4.9.1 / opentelemetry-proto v1.10.0 (third_party submodule)
#
# 使い方: sh scripts/regen-otlp-pb.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.venv-otlp"
PROTO_ROOT="$REPO_ROOT/third_party/opentelemetry-proto"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
GENERATOR="$NANOPB/generator/nanopb_generator.py"
OUT="$REPO_ROOT/src/runtime/otlp/pb"

# 生成対象 (import される common/resource も含め全部生成する必要がある)
PROTOS="
opentelemetry/proto/common/v1/common.proto
opentelemetry/proto/resource/v1/resource.proto
opentelemetry/proto/metrics/v1/metrics.proto
opentelemetry/proto/trace/v1/trace.proto
opentelemetry/proto/logs/v1/logs.proto
opentelemetry/proto/collector/metrics/v1/metrics_service.proto
opentelemetry/proto/collector/trace/v1/trace_service.proto
opentelemetry/proto/collector/logs/v1/logs_service.proto
"

if [ ! -f "$GENERATOR" ]; then
  echo "error: the nanopb generator is missing ($GENERATOR). Check that the submodules are initialized:" >&2
  echo "       git submodule update --init third_party/nanopb third_party/opentelemetry-proto" >&2
  exit 1
fi

# --- 隔離 venv を冪等にブートストラップ ---
if [ ! -x "$VENV/bin/python" ]; then
  echo "[regen-otlp-pb] creating venv: $VENV"
  python3 -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c "import grpc_tools.protoc" >/dev/null 2>&1; then
  echo "[regen-otlp-pb] installing grpcio-tools into venv"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet grpcio-tools
fi

echo "[regen-otlp-pb] protoc: $("$VENV/bin/python" -m grpc_tools.protoc --version)"
echo "[regen-otlp-pb] generating into $OUT"
rm -rf "$OUT/opentelemetry"
mkdir -p "$OUT"

# shellcheck disable=SC2086
"$VENV/bin/python" "$GENERATOR" \
  -I "$PROTO_ROOT" \
  -D "$OUT" \
  $PROTOS

echo "[regen-otlp-pb] generated files:"
find "$OUT" -name '*.pb.*' | sort | sed "s|$REPO_ROOT/||"
echo "[regen-otlp-pb] done."
