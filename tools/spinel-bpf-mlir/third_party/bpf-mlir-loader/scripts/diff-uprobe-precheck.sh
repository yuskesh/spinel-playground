#!/bin/bash
# scripts/diff-uprobe-precheck.sh — E008 H3: bml-precheck と ebpf-precheck を、bpf-mlir の uprobe の ELF (kernel/uprobe/mlir*) と E015 の
# fixture (up・argsum) × uprobe の binary の全て (scripts/diff-dwarf.sh と同じ fixture の列) の組で — 記録した caps (corpus の uprobe_ok の
# caps.json の uprobe_binary を組の binary に) — 出力の全体 (JSON — Unmet の文まで) を比べる。root 不要。
#
#   scripts/diff-uprobe-precheck.sh [TOOLS_DIR]     # 既定は build/tools
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
W="$HERE/build/tmp/diff-uprobe-precheck"
rm -rf "$W"; mkdir -p "$W/elf"
BM="$HERE/third_party/bpf-mlir"
EC="$HERE/build/bpf-mlir/bin/ebpf-compile"
for m in "$BM"/kernel/uprobe/mlir*/*.mlir; do
  d=$(dirname "$m"); n="$(basename "$d")-$(basename "$m" .mlir)"
  "$EC" "$m" --schema "$d/schema.json" -o "$W/elf/$n.bpf.o" || exit 1
done
for f in up argsum; do "$EC" "$HERE/test/abi/fixture/$f.mlir" --schema "$HERE/test/abi/fixture/$f.schema.json" -o "$W/elf/fx-$f.bpf.o" || exit 1; done
mapfile -t BINS < <({ ls "$BM"/conformance/requirements/bin/*; find "$BM/kernel/uprobe/fixture" -type f -perm -u+x -path '*/bin*'; } | LC_ALL=C sort -u)
CAPS="$BM/conformance/requirements/cases/uprobe_ok/caps.json"
n=0 bad=0
for e in "$W"/elf/*.bpf.o; do
  /opt/llvm-23.1.1/bin/llvm-objcopy --dump-section .ebpf_requirements="$W/req.txt" "$e" "$W/tmp.o" 2>/dev/null
  prog=$(awk -F'\t' '$1=="attach" && $3=="uprobe"{print $2; exit}' "$W/req.txt")
  # 記録の caps に ELF の helper と map の型の答え (true) を足す — uprobe の照合まで進むため (照合の他の段は corpus が見る)
  extra=$(awk -F'\t' '$1=="program"{t[$2]=$3} $1=="helper"{printf "%s/%s\n", t[$2], $3} $1=="map"{printf "map:%s\n", $3}' "$W/req.txt" |
    jq -R -s 'split("\n") | map(select(length > 0)) | reduce .[] as $k ({helper: {}, map_type: {}};
      if ($k | startswith("map:")) then .map_type[$k[4:]] = {value: true} else .helper[$k] = {value: true} end)')
  for b in "${BINS[@]}"; do
    n=$((n + 1))
    # E037 (ebpf-caps 6): helper と map_type は権限に依る問い — privileged_queries に。記録は root (corpus の probed_as) — --load-as で同じ権限に
    jq --arg p "$prog" --arg f "$b" --argjson x "$extra" \
      '.queries.uprobe_binary = {($p): {file: $f}} | .privileged_queries.helper += $x.helper | .privileged_queries.map_type += $x.map_type' "$CAPS" > "$W/caps.json"
    LA=--load-as=0:000001ffffffffff
    gr=0; "$TOOLS/ebpf-precheck" --loader=cilium-v0.22 --caps="$W/caps.json" "$LA" "$e" > "$W/g.json" 2>/dev/null || gr=$?
    cr=0; "$TOOLS/bml-precheck" --loader=cilium-v0.22 --caps="$W/caps.json" "$LA" "$e" > "$W/c.json" 2>/dev/null || cr=$?
    g=$(jq -cS 'del(.versions.bpf_mlir)' "$W/g.json"); c=$(jq -cS 'del(.versions.bpf_mlir)' "$W/c.json")
    if [ "$gr" != "$cr" ] || [ "$g" != "$c" ]; then
      bad=$((bad + 1)); echo "DIFF $(basename "$e") × $(basename "$b"): go=$gr c=$cr"
      diff <(jq -S 'del(.versions.bpf_mlir)' "$W/g.json") <(jq -S 'del(.versions.bpf_mlir)' "$W/c.json") | head -8
    else
      jq -r --arg k "$(basename "$e") × $(basename "$b")" '"\($k)\t\(.result)\t\([.unmet[]?.kind] | join(","))"' "$W/c.json" >> "$W/summary.tsv"
    fi
  done
done
echo "diff-uprobe-precheck: 組 $n、差 $bad — $([ "$bad" = 0 ] && echo ok || echo FAIL)"
[ "$bad" = 0 ]
