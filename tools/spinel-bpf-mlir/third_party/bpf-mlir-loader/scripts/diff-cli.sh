#!/bin/bash
# scripts/diff-cli.sh — bml-precheck (C) と ebpf-precheck (Go) の引数の扱い (usage_error の文・exit・判定) の差動 (E002)。
#
#   scripts/diff-cli.sh [TOOLS_DIR]     # 既定は build/tools (ebpf-precheck を含む — sweep-precheck.sh が build する)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-cli"
rm -rf "$W"
mkdir -p "$W"
C="$HERE/third_party/bpf-mlir/conformance/requirements/cases/xdp_ok"
L="$W/loader.json"
jq .loader "$C/caps.json" > "$L"
jq '.name = "other"' "$C/caps.json" > /dev/null
jq '.loader.name = "other"' "$C/caps.json" > "$W/caps-other.json"
n=0 bad=0
while IFS= read -r args; do
  n=$((n + 1))
  eval "set -- $args"
  gr=0; "$TOOLS/ebpf-precheck" "$@" > "$W/g.json" 2>/dev/null || gr=$?
  cr=0; "$TOOLS/bml-precheck" "$@" > "$W/c.json" 2>/dev/null || cr=$?
  g=$(jq -cS 'del(.versions.bpf_mlir)' "$W/g.json"); c=$(jq -cS 'del(.versions.bpf_mlir)' "$W/c.json")
  if [ "$gr" != "$cr" ] || [ "$g" != "$c" ]; then
    bad=$((bad + 1))
    echo "DIFF [$args] go=$gr c=$cr"
    diff <(jq -S 'del(.versions.bpf_mlir)' "$W/g.json") <(jq -S 'del(.versions.bpf_mlir)' "$W/c.json") | head -6 || true
  fi
done <<ARGS
--loader=cilium-v0.22 --caps=$C/caps.json $C/object.bpf.o
-loader cilium-v0.22 -caps $C/caps.json $C/object.bpf.o
--loader-file=$L --caps=$C/caps.json $C/object.bpf.o
--loader=cilium-v0.22 --loader-file=$L --caps=$C/caps.json $C/object.bpf.o
--caps=$C/caps.json $C/object.bpf.o
--loader=nope --caps=$C/caps.json $C/object.bpf.o
--loader=cilium-v0.22 $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json
--loader=cilium-v0.22 --caps=$C/caps.json $C/object.bpf.o extra
--loader=cilium-v0.22 --caps=$C/caps.json --binary=a=b $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json --schema-sha256=abc $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json --schema-sha256=abc --hint=H $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json --requirements=$C/want.json
--loader=cilium-v0.22 --caps=$C/caps.json /nonexistent.o
--loader=cilium-v0.22 --caps=/nonexistent.json $C/object.bpf.o
--loader=cilium-v0.22 --caps=$W/caps-other.json $C/object.bpf.o
--loader-file=/nonexistent.json --caps=$C/caps.json $C/object.bpf.o
--bogus
--loader
--loader=cilium-v0.22 --caps=$C/caps.json -- $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json --live=false $C/object.bpf.o
--loader=cilium-v0.22 --caps=$C/caps.json --live=maybe $C/object.bpf.o
--version
--version=false --loader=cilium-v0.22 --caps=$C/caps.json $C/object.bpf.o
ARGS
echo "diff-cli: $n cases, $bad diff"
[ "$n" -gt 0 ] && [ "$bad" -eq 0 ]
