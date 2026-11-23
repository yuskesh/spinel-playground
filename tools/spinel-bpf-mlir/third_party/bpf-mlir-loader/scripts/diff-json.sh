#!/bin/bash
# scripts/diff-json.sh — C の JSON の読み (§13 — caps.json・maps.json・loader の宣言) と Go の bpf-mlir の厳しい読み
# (requirements.ParseRecordedCaps・bindrt.ParseMapDecls・DecodeStrictJSON — E290) の差動 (E002)。
# kind ごとに corpus の JSON を種に決定的な変異を作り、判定 (ok / invalid と規則) を比べる。
#
#   scripts/diff-json.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 20 build/tools
#
# 許す差は無い (bpf-mlir v0.13.0 の E302 から Go も文字列の中の \u0000 を nul の規則で止める — E002 の名指しの差 c_strict[nul] は無くなった)。
# 件数も照合する。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-json.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-20}"
TOOLS="${3:-$HERE/build/tools}"
[ -x "$TOOLS/json_case" ] || { echo "diff-json: $TOOLS/json_case が無い (scripts/build-tools.sh)" >&2; exit 1; }
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-json"
rm -rf "$W"
mkdir -p "$W"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/json-oracle" ./cmd/json-oracle &&
  GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/mutate" ./cmd/mutate)
C="$HERE/third_party/bpf-mlir/conformance/requirements"
total=0 same=0 nul=0 bad=0
: > "$W/bad.txt"
for kind in caps maps loader; do
  mkdir -p "$W/$kind/seeds" "$W/$kind/mut"
  i=0
  case "$kind" in
  caps) for f in "$C"/cases/*/caps.json; do cp "$f" "$W/$kind/seeds/$i.json"; i=$((i + 1)); done ;;
  maps) for f in "$C"/maps/*/maps.json; do cp "$f" "$W/$kind/seeds/$i.json"; i=$((i + 1)); done ;;
  loader) for f in "$C"/cases/*/caps.json; do jq .loader "$f" > "$W/$kind/seeds/$i.json"; i=$((i + 1)); done ;;
  esac
  for f in "$C"/json/"$kind"_*/input.json; do cp "$f" "$W/$kind/seeds/$i.json"; i=$((i + 1)); done
  "$W/mutate" -json -seed "$SEED" -n "$N" -out "$W/$kind/mut" "$W/$kind"/seeds/*.json
  { find "$W/$kind/seeds" -type f; find "$W/$kind/mut" -type f; } | LC_ALL=C sort > "$W/$kind/list"
  xargs -a "$W/$kind/list" "$W/json-oracle" "$kind" > "$W/$kind/go.out"
  xargs -a "$W/$kind/list" "$TOOLS/json_case" "$kind" > "$W/$kind/c.out"
  n=$(wc -l < "$W/$kind/list")
  [ "$n" -gt 0 ] && [ "$(wc -l < "$W/$kind/go.out")" -eq "$n" ] && [ "$(wc -l < "$W/$kind/c.out")" -eq "$n" ] ||
    { echo "diff-json: $kind の件数が合わない" >&2; exit 1; }
  total=$((total + n))
  while IFS=$'\t' read -r gp gres grule cp cres crule; do
    if [ "$gp" != "$cp" ]; then echo "path mismatch $gp $cp" >> "$W/bad.txt"; bad=$((bad + 1)); continue; fi
    if [ "$gres" = "$cres" ] && [ "$grule" = "$crule" ]; then same=$((same + 1)); continue; fi
    echo "$kind $gp go=$gres/$grule c=$cres/$crule" >> "$W/bad.txt"
    bad=$((bad + 1))
  done < <(paste <(awk -F'\t' '{print $1"\t"$2"\t"($3==""?"-":$3)}' "$W/$kind/go.out") <(awk -F'\t' '{print $1"\t"$2"\t"($3==""?"-":$3)}' "$W/$kind/c.out"))
done
echo "diff-json: seed=$SEED inputs=$total same=$same bad=$bad"
[ $((same + nul + bad)) -eq "$total" ] || { echo "diff-json: 件数が合わない" >&2; exit 1; }
[ "$bad" -eq 0 ] || { echo "diff-json: 差 — $W/bad.txt" >&2; head -8 "$W/bad.txt" >&2; exit 1; }
