#!/bin/bash
# scripts/sweep-precheck.sh — bpf-mlir の tree の ELF (.ebpf_requirements を持つもの) を、試験の側の Go の capsgen が作る記録
# (決定的な擬似乱数の答え・loader の宣言) で bml-precheck (C) と ebpf-precheck (Go) の両方に照合させ、出力を比べる (E002)。
#
#   scripts/sweep-precheck.sh [SEED] [TOOLS_DIR]     # 既定 1 build/tools
#
# 比べるもの: exit・result・unmet (kind・program・name・id・blocks_load・detail の文)・parse_error・versions の format_max・policy・
# object_format・probed_as・loader。比べないもの: versions.bpf_mlir (道具の版)。error の文は requirements_invalid 以外で比べ、
# requirements_invalid (ELF の読みの誤り — Go の debug/elf の文) は数えて別に出す。件数も照合する。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/sweep-precheck.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
TOOLS="${2:-$HERE/build/tools}"
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/sweep-precheck"
rm -rf "$W"
mkdir -p "$W/cases"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/capsgen" ./cmd/capsgen)
# SWEEP_MAPS=1: 試験の側の declgen が ELF ごとの map の宣言 (§12 — 一致の宣言に 1 つの変異) を作り、両方に --maps で渡す (E003)
# DECLGEN_GMUT=N (SWEEP_MAPS と): 全ての ELF に globals を宣言し N 番の global の変異だけ (E308 の網羅 — declgen の mutateGlobals)
[ -z "${SWEEP_MAPS:-}" ] || (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/declgen" ./cmd/declgen)
# 毎回 build する (submodule の版を上げた後の古い binary を使わない — Go の build の cache で速い)
(cd "$HERE/third_party/bpf-mlir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" build -o "$TOOLS/ebpf-precheck" ./kernel/cmd/ebpf-precheck)
[ -z "$(git -C "$HERE/third_party/bpf-mlir" status --porcelain)" ] || { echo "sweep: third_party/bpf-mlir が汚れた" >&2; exit 1; }
# .ebpf_requirements を持つ ELF (内容で重複を除く)
find "$HERE/third_party/bpf-mlir" -name '*.o' -type f -not -path '*/build/*' | LC_ALL=C sort > "$W/all"
: > "$W/elfs"
declare -A seen
while read -r f; do
  # pipe の grep -q は早く終わり readelf が SIGPIPE で落ちる — pipefail の下では黙って ELF を落とす (E002 で見つけた) — 出力を先に取る
  secs=$("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -S "$f" 2>/dev/null || true)
  if grep -q "\.ebpf_requirements" <<< "$secs"; then
    h=$(sha256sum "$f" | cut -c1-64)
    [ -n "${seen[$h]:-}" ] && continue
    seen[$h]=1
    echo "$f" >> "$W/elfs"
  fi
done < "$W/all"
# E039: 1 回の呼び出しで (xargs は 128 KiB で分け、capsgen / declgen の添字 — case の dir の名前と seed — が batch ごとに 0 から始まり上書きした。
# v1.7.0 の tree の 1142 の path で初めて分かれた — 件数の照合が捕まえた)
mapfile -t ELFS < "$W/elfs"
"$W/capsgen" -seed "$SEED" -out "$W/cases" "${ELFS[@]}"
MAPS_ARG=()
if [ -n "${SWEEP_MAPS:-}" ]; then
  mapfile -t CDIRS < <(find "$W/cases" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  "$W/declgen" -seed "$SEED" -gmut "${DECLGEN_GMUT:--1}" "${CDIRS[@]}"
fi
n=$(wc -l < "$W/elfs")
norm='del(.versions.bpf_mlir) | (if .result == "requirements_invalid" then del(.error) else . end)'
same=0 diff=0 inv_err_diff=0
: > "$W/diffs.txt"
for d in "$W"/cases/*/; do
  obj=$(cat "$d/object")
  MAPS_ARG=(); [ -z "${SWEEP_MAPS:-}" ] || MAPS_ARG=(--maps="$d/maps.json")
  gorc=0; "$TOOLS/ebpf-precheck" --loader-file="$d/loader.json" --caps="$d/caps.json" "${MAPS_ARG[@]}" "$obj" > "$d/go.json" || gorc=$?
  crc=0; "$TOOLS/bml-precheck" --loader-file="$d/loader.json" --caps="$d/caps.json" "${MAPS_ARG[@]}" "$obj" > "$d/c.json" || crc=$?
  g=$(jq -cS "$norm" "$d/go.json"); c=$(jq -cS "$norm" "$d/c.json")
  if [ "$gorc" = "$crc" ] && [ "$g" = "$c" ]; then
    same=$((same + 1))
    if [ "$(jq -r .result "$d/go.json")" = requirements_invalid ] && [ "$(jq -r .error "$d/go.json")" != "$(jq -r .error "$d/c.json")" ]; then
      inv_err_diff=$((inv_err_diff + 1))
    fi
  else
    diff=$((diff + 1))
    { echo "== $d ($obj) exit go=$gorc c=$crc"; diff <(jq -S "$norm" "$d/go.json") <(jq -S "$norm" "$d/c.json") | head -20 || true; } >> "$W/diffs.txt"
  fi
done
echo "sweep-precheck: seed=$SEED${SWEEP_MAPS:+ (maps)} elfs=$n same=$same diff=$diff (requirements_invalid の error の文の違い $inv_err_diff)"
echo "  Go の result の内訳: $(cat "$W"/cases/*/go.json | jq -r .result | sort | uniq -c | tr '\n' ' ')"
[ "$n" -gt 0 ] && [ $((same + diff)) -eq "$n" ] || { echo "sweep: 件数が合わない" >&2; exit 1; }
[ "$diff" -eq 0 ] || { echo "sweep: 差 — $W/diffs.txt" >&2; head -30 "$W/diffs.txt" >&2; exit 1; }
