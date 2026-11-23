#!/bin/bash
# scripts/build-oracles.sh — 試験の側の Go の oracle を毎回 build する (VM の中は Go の module の cache が無いので host で — scripts/run-in-vm.sh)。
# 在れば使う形にしない (submodule の版を上げた後に古い oracle で比べない)。
#
#   scripts/build-oracles.sh [OUT]     # 既定 build/oracles — kbtf-oracle・mutate・kbtf-live
#   eval "$(scripts/build-oracles.sh --env)"   # KBTF_ORACLE・MUTATE・KBTF_LIVE を build して export
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/build-oracles.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENV=0
[ "${1:-}" != "--env" ] || { ENV=1; shift; }
OUT="${1:-$HERE/build/oracles}"
mkdir -p "$OUT"
GO="${GO:-/usr/local/go/bin/go}"
for c in kbtf-oracle mutate kbtf-live tpbtf-oracle load-oracle wave-proof run-oracle attach-caller-oracle attach-tp-oracle usdt-attach-oracle ksys-attach-oracle nf-attach-oracle strarg-live; do
  (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$OUT/$c" "./cmd/$c") >&2
done
# E035: bpf-mlir の traceattach (cilium の attach の runner — submodule の source をそのまま、波 1 の attach の差動の相手)
(cd "$HERE/third_party/bpf-mlir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" build -o "$OUT/traceattach" ./kernel/cmd/traceattach) >&2
if [ "$ENV" = 1 ]; then
  printf 'export KBTF_ORACLE=%q MUTATE=%q KBTF_LIVE=%q TPBTF_ORACLE=%q STRARG_LIVE=%q\n' "$OUT/kbtf-oracle" "$OUT/mutate" "$OUT/kbtf-live" "$OUT/tpbtf-oracle" "$OUT/strarg-live"
else
  echo "$OUT"
fi
