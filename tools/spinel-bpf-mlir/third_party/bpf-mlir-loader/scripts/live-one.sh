#!/bin/bash
# scripts/live-one.sh — E004 の live の差動の 1 つの ELF (live-diff.sh から — 呼び手の権限で走る)。
#
#   scripts/live-one.sh <ELF> <作業の dir> <TOOLS_DIR>
#
# (A) 両方の `--live --record` の caps.json を byte で比べる (unknown と error の文も — E010: E004 の H1 の「文は比べない」を外した、文は契約)。
# (B) 判定の交差: C の live の出力 == Go に C の記録を --caps で渡した出力、Go の live の出力 == C に Go の記録を --caps で渡した出力
#     (versions.bpf_mlir を除いて全て)。結果の 1 行を <dir>/verdict に: "<A> <B-c> <B-go> <go の result> <exit go>/<exit c>"
set -uo pipefail
ELF="$1"; D="$2"; T="$3"
mkdir -p "$D"
L=--loader=cilium-v0.22
IN=("$ELF"); case "$ELF" in *.req.txt) IN=(--requirements="$ELF") ;; esac
gr=0; "$T/ebpf-precheck" "$L" --live --record="$D/go.caps.json" "${IN[@]}" > "$D/go.live.json" 2> "$D/go.err" || gr=$?
cr=0; "$T/bml-precheck" "$L" --live --record="$D/c.caps.json" "${IN[@]}" > "$D/c.live.json" 2> "$D/c.err" || cr=$?
# E010: 前は unknown / error の文を空にした (2 つの食い違いを隠した)。今は名指しの除外の表 (scripts/live-text-exclusions.tsv) の
# error の文だけを <名前> に (side は go / c — 片方だけが一致すれば差は見える)、他の文は byte で比べる
norm() {
  local f=$1 side=$2 args=() name gre cre why
  while IFS=$'\t' read -r name gre cre why; do
    case "$name" in "" | \#*) continue ;; esac
    if [ "$side" = go ]; then re=$gre; else re=$cre; fi
    # E042: unknown の答えの文も (K1 — kfunc の load の probe の verifier の log の文)
    args+=(-e "s/^( *\"(error|unknown)\": \")${re}(\",?)\$/\\1<${name}>\\3/")
  done < "$(dirname "$0")/live-text-exclusions.tsv"
  if [ ${#args[@]} -eq 0 ]; then cat "$f"; else sed -E "${args[@]}" "$f"; fi
}
a=same
if [ ! -f "$D/go.caps.json" ] || [ ! -f "$D/c.caps.json" ]; then
  [ -f "$D/go.caps.json" ] || [ -f "$D/c.caps.json" ] && a=diff || a=none
elif ! cmp -s <(norm "$D/go.caps.json" go) <(norm "$D/c.caps.json" c); then
  a=diff
fi
# E037 (bpf-mlir E438): --caps の出力は load_as (照合の load の権限) を持つ — live の出力との判定の交差では比べない (run_as と同じ値)
j='del(.versions.bpf_mlir) | del(.load_as)'
bc=none bg=none
if [ -f "$D/c.caps.json" ]; then
  x=0; "$T/ebpf-precheck" "$L" --caps="$D/c.caps.json" "${IN[@]}" > "$D/go.onc.json" 2>/dev/null || x=$?
  [ "$x" = "$cr" ] && [ "$(jq -cS "$j" "$D/go.onc.json")" = "$(jq -cS "$j" "$D/c.live.json")" ] && bc=same || bc=diff
fi
if [ -f "$D/go.caps.json" ]; then
  x=0; "$T/bml-precheck" "$L" --caps="$D/go.caps.json" "${IN[@]}" > "$D/c.ongo.json" 2>/dev/null || x=$?
  [ "$x" = "$gr" ] && [ "$(jq -cS "$j" "$D/c.ongo.json")" = "$(jq -cS "$j" "$D/go.live.json")" ] && bg=same || bg=diff
fi
# E020: 両方とも記録を作らない ELF (requirements を読めない — 照合の問いが無い) は live の出力そのもの (exit と JSON の全体) を比べる
# (tree に壊れた ELF が増えた — bpf-mlir results/E343/scratch/ev.bpf.o。前は none のまま比べなかった)
if [ "$a" = none ] && [ "$gr" = "$cr" ] && [ "$(jq -cS "$j" "$D/go.live.json" 2>/dev/null)" = "$(jq -cS "$j" "$D/c.live.json" 2>/dev/null)" ]; then
  a=same bc=same bg=same
fi
echo "$a $bc $bg $(jq -r .result "$D/go.live.json" 2>/dev/null || echo ?) $gr/$cr" > "$D/verdict"
