#!/bin/bash
# scripts/spinel-oracle.sh — E007 の差動の oracle: spinel-bpf-mlir の Go の loader の試験の c-archive (-tags spinelbpf_test) を、spinel の
# repo を build/tmp に clone して build する (spinel の repo は読むだけ — この repo は下流を編集しない)。
#
#   scripts/spinel-oracle.sh [COMMIT]     # 既定は E007 の固定 5ce7602。出力は build/tmp/spinel-oracle/{libspinelbpf_test.a, commit}
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/spinel-oracle.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="${1:-5ce7602}"
SRC="${SPINEL_REPO:?set SPINEL_REPO to a spinel-bpf-mlir checkout}"   # Spinel Extended: no default sibling checkout (bml defaulted to <path>/spinel-bpf-mlir)
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/spinel-oracle"
rm -rf "$W"; mkdir -p "$W"
git clone -q --no-checkout "$SRC" "$W/src"
git -C "$W/src" checkout -q "$COMMIT"
git -C "$W/src" rev-parse HEAD > "$W/commit"
(cd "$W/src" && GOFLAGS=-mod=mod GOTOOLCHAIN=local "${GO:-/usr/local/go/bin/go}" build -tags spinelbpf_test -buildmode=c-archive \
  -o "$W/libspinelbpf_test.a" ./loader)
echo "$W/libspinelbpf_test.a ($(cut -c1-12 "$W/commit"))"
