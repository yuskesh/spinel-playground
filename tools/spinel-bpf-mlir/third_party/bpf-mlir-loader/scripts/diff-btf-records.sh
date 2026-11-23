#!/bin/bash
# scripts/diff-btf-records.sh — 壊れた .BTF の ELF で records を宣言した --maps の照合を C (bml-precheck) と Go (ebpf-precheck) で比べる (E003 の H3)。
# corpus の maps の records の case (object.bpf.o を持つ) を種に、.BTF の section の中だけを決定的に変異させる。
#
#   scripts/diff-btf-records.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 100 build/tools
#
# 許す差は無い: bpf-mlir v0.13.0 の E304 で Go の go/layout の parseBTF に境界の検査が入り、壊れた BTF で Go も format の誤り (英語の安定した文 —
# C は byte で写す)。E003 の名指しの差 go_panic (seed 1 の 311) は一致に変わった — Go の panic は全て失敗として数える。件数も照合する。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-btf-records.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-100}"
TOOLS="${3:-$HERE/build/tools}"
[ -x "$TOOLS/bml-precheck" ] && [ -x "$TOOLS/ebpf-precheck" ] || { echo "diff-btf-records: $TOOLS に bml-precheck と ebpf-precheck が要る (build-tools.sh・sweep-precheck.sh)" >&2; exit 1; }
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-btf-records"
rm -rf "$W"
mkdir -p "$W/seeds" "$W/mut"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/mutate" ./cmd/mutate)
C="$HERE/third_party/bpf-mlir/conformance/requirements/maps"
CAPS="$HERE/third_party/bpf-mlir/conformance/requirements/cases/xdp_ok/caps.json"
i=0
for d in "$C"/*/; do
  [ -f "$d/object.bpf.o" ] && jq -e '.records' "$d/maps.json" > /dev/null 2>&1 || continue
  cp "$d/object.bpf.o" "$W/seeds/$(printf '%03d' $i).o"
  cp "$d/maps.json" "$W/seeds/$(printf '%03d' $i).maps.json"
  i=$((i + 1))
done
"$W/mutate" -btf -seed "$SEED" -n "$N" -out "$W/mut" "$W"/seeds/*.o
total=0 same=0 panic=0 bad=0
: > "$W/bad.txt"
for f in "$W"/mut/*.txt; do
  total=$((total + 1))
  idx=$(basename "$f" | cut -c1-3)
  maps="$W/seeds/$idx.maps.json"
  # E037 (判定の版 10): corpus の記録は root — --load-as で同じ権限に (非 root の gate でも権限に依る問いを Unknown にしない — 照合の網羅を保つ)
  gr=0; "$TOOLS/ebpf-precheck" --loader=cilium-v0.22 --caps="$CAPS" --load-as=0:000001ffffffffff --maps="$maps" "$f" > "$f.go.json" 2> "$f.go.err" || gr=$?
  cr=0; "$TOOLS/bml-precheck" --loader=cilium-v0.22 --caps="$CAPS" --load-as=0:000001ffffffffff --maps="$maps" "$f" > "$f.c.json" 2> "$f.c.err" || cr=$?
  if [ ! -s "$f.go.json" ] && grep -q '^panic:' "$f.go.err"; then
    panic=$((panic + 1)) # E304 の後は Go の panic は無いはず — 失敗
    echo "$f: Go が panic、C は exit $cr ($(jq -c '.result' "$f.c.json" 2> /dev/null))" >> "$W/bad.txt"; bad=$((bad + 1)); continue
  fi
  g=$(jq -cS 'del(.versions.bpf_mlir)' "$f.go.json" 2> /dev/null || echo invalid); c=$(jq -cS 'del(.versions.bpf_mlir)' "$f.c.json" 2> /dev/null || echo invalid)
  if [ "$gr" = "$cr" ] && [ "$g" = "$c" ]; then same=$((same + 1)); continue; fi
  echo "$f: exit go=$gr c=$cr" >> "$W/bad.txt"
  diff <(jq -S 'del(.versions.bpf_mlir)' "$f.go.json" 2> /dev/null) <(jq -S 'del(.versions.bpf_mlir)' "$f.c.json" 2> /dev/null) | head -8 >> "$W/bad.txt" || true
  bad=$((bad + 1))
done
echo "diff-btf-records: seed=$SEED seeds=$i inputs=$total same=$same go_panic=$panic bad=$bad"
[ "$total" -gt 0 ] && [ $((same + bad)) -eq "$total" ] || { echo "diff-btf-records: 件数が合わない" >&2; exit 1; }
[ "$bad" -eq 0 ] || { echo "diff-btf-records: 差 — $W/bad.txt" >&2; head -20 "$W/bad.txt" >&2; exit 1; }
