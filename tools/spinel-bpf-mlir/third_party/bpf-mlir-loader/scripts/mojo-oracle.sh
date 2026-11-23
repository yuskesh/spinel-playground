#!/bin/bash
# scripts/mojo-oracle.sh — E012 の差動の oracle: mojo-bpf-mlir の Go の loader の試験の c-archive (-tags mojobpf_test) を、mojo の repo を
# build/tmp に clone して build する (mojo の repo は読むだけ — この repo は下流を編集しない。spinel-oracle.sh と同じ形)。
#
#   scripts/mojo-oracle.sh [COMMIT]     # 既定は E013 の固定 5a53a6d (E012 は e87f625 — E099 の 2 度目の detach の OK・load の入口の変更の前)。出力は build/tmp/mojo-oracle/{libmojobpf_test.a, commit}
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/mojo-oracle.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="${1:-5a53a6d}"
SRC="${MOJO_REPO:?set MOJO_REPO to a mojo-bpf-mlir checkout}"   # Spinel Extended: no default sibling checkout (bml defaulted to <path>/mojo-bpf-mlir)
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/mojo-oracle"
rm -rf "$W"; mkdir -p "$W"
git clone -q --no-checkout "$SRC" "$W/src"
git -C "$W/src" checkout -q "$COMMIT"
git -C "$W/src" rev-parse HEAD > "$W/commit"
(cd "$W/src" && GOFLAGS=-mod=mod GOTOOLCHAIN=local "${GO:-/usr/local/go/bin/go}" build -tags mojobpf_test -buildmode=c-archive \
  -o "$W/libmojobpf_test.a" ./loader)
echo "$W/libmojobpf_test.a ($(cut -c1-12 "$W/commit"))"
