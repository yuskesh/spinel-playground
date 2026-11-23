#!/usr/bin/env bash
#
# run_record_span_parity.sh — E377: 型付き consumer の全プロパティが
# 「Ruby が見る値 == span に出る値」であることを、合成 record で機械的に突き合わせる。
#
# record_span_parity_test.c が otlp_agent.c を TU ごと include して、
#   accessor (spnl_rec_<ch>_<prop> = ev.<prop>)  と
#   builder  (<ch>_fill_span      = 簡潔形 push / 明示形 to_span の共通経路)
# を同じ record に適用し、属性値・span 名・span の長さと突き合わせる。
#
# 実カーネル / 実 probe / collector は不要。libbpf は otlp_agent.c が ringbuf drain に
# 使うのでリンクだけ要る (drain は呼ばない) => Linux (container) で走る。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
OTLP="$REPO_ROOT/src/runtime/otlp"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PB_C=$(find "$OTLP/pb/opentelemetry" -name '*.pb.c' | sort)

INC="-I $REPO_ROOT/include -I $OTLP -I $OTLP/pb -I $NANOPB -I $REPO_ROOT/src/runtime"

# 被験体 (test TU = otlp_agent.c を include した TU) だけ厳格に。他の runtime/nanopb は
# 巻き添えで -Werror を課さない (この test の関心ではないし、既存 runner も同じ扱い)。
echo "[e377] compiling record/span parity test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -c $INC \
  tests/runtime/record_span_parity_test.c -o "$TMP/parity.o"

# shellcheck disable=SC2086
"$CC" -O2 $INC "$TMP/parity.o" \
  "$OTLP/otlp_traces.c" "$OTLP/otlp_metrics.c" "$OTLP/otlp_logs.c" \
  "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" "$OTLP/otlp_json.c" \
  "$OTLP/otlp_httpspan.c" "$OTLP/otlp_enrich.c" "$OTLP/otlp_k8s.c" \
  "$OTLP/otlp_peer.c" "$OTLP/otlp_cri.c" "$OTLP/otlp_recmetric.c" \
  "$REPO_ROOT/src/runtime/spnl_runtime.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -lbpf -lelf -lz \
  -o "$TMP/record_span_parity"

echo "[e377] running"
"$TMP/record_span_parity"

# cgid は属性にならないが層 2 enricher の入力 — 有効判定が lazy one-shot なので別プロセスで。
echo
"$TMP/record_span_parity" --cgid-enricher
