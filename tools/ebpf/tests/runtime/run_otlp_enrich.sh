#!/usr/bin/env bash
# run_otlp_enrich.sh — E313: 層 2 enricher レジストリ (ADR-014) の単体テスト。
#  registry introspection (k8s->peer, per-signal mask) + no-op + CONN の k8s->peer 属性順序
#  + DNS の peer 除外 (byte-identical) を検証。libbpf/nanopb 非依存 (host で完結、fake
#  kubepods 階層の inode を cgid として使う)。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
OTLP="$REPO_ROOT/src/runtime/otlp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[enrich] enricher registry 単体テスト (otlp_enrich + otlp_k8s + otlp_cri + otlp_peer)"
"$CC" -O2 -Wall -Wextra -I "$OTLP" -I "$REPO_ROOT/include" \
  tests/runtime/otlp_enrich_test.c \
  "$OTLP/otlp_enrich.c" "$OTLP/otlp_k8s.c" "$OTLP/otlp_cri.c" "$OTLP/otlp_peer.c" \
  -o "$TMP/enrich"
"$TMP/enrich"
echo "[enrich] OK"
