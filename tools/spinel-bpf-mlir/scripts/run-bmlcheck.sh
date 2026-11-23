#!/bin/bash
# scripts/run-bmlcheck.sh — P021 E085 (mojo-bpf-mlir P026 E111 の写し): host の live で bml の照合 (bml-precheck — C) と Go の reference (ebpf-precheck) を ELF ごと・loader ごとに比べる
# (bml の scripts/live-one.sh と同じ比べ方 — bml の tree の script は使わず spinel の側に同じ形を書く)。root で走らせる (live の問い合わせは program の load)。
#
#   sudo scripts/run-bmlcheck.sh <ELF の dir> <出力の dir> <道具の dir (scripts/prep-bmlcheck.sh)>
#
# 1 行 / (ELF, loader): "<ELF> <loader> <A> <B-c> <B-go> <Go の result> <exit go>/<exit c> <Go の Unmet の kind (blocks の印 !)>"
#   A:    両方の `--live --record` の caps.json が byte で同じか (same / diff / none)
#   B-c:  C の live の出力 == Go に C の記録を --caps で渡した出力 (versions.bpf_mlir と load_as を除く) — B-go は逆向き
#         load_as (bpf-mlir v1.6.0 E438 — 記録の caps を使う照合の load の権限) は --caps の出力にだけ在る — 2 つの --caps の出力 (Go on C・C on Go) で同じことを
#         別に見て、違えば B-c・B-go を diff に (E107 — mojo-bpf-mlir E136 と同じ形)
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
[ "$(id -u)" = 0 ] || { echo "run-bmlcheck: run as root" >&2; exit 2; }
E="$1"; O="$2"; T="$3"
# E167: 比べの両側の道具が要る (公開 bpf-mlir では prep-bmlcheck が Go の reference を作らない — 片側だけの比べを黙って出さない)
for b in ebpf-precheck bml-precheck; do [ -x "$T/$b" ] || { echo "run-bmlcheck: $T/$b is missing — scripts/prep-bmlcheck.sh builds it (ebpf-precheck needs kernel/cmd/ebpf-precheck in third_party/bpf-mlir)" >&2; exit 2; }; done
mkdir -p "$O"
j='del(.versions.bpf_mlir, .load_as)'
for elf in "$E"/*.bpf.o; do
  n=$(basename "$elf" .bpf.o)
  for L in cilium-v0.22 bml-libbpf-v1.7; do
    D="$O/$n.$L"; mkdir -p "$D"
    gr=0; "$T/ebpf-precheck" --loader="$L" --live --record="$D/go.caps.json" "$elf" > "$D/go.live.json" 2> "$D/go.err" || gr=$?
    cr=0; "$T/bml-precheck" --loader="$L" --live --record="$D/c.caps.json" "$elf" > "$D/c.live.json" 2> "$D/c.err" || cr=$?
    a=same
    if [ ! -f "$D/go.caps.json" ] || [ ! -f "$D/c.caps.json" ]; then
      a=none
    elif ! cmp -s "$D/go.caps.json" "$D/c.caps.json"; then
      a=diff
    fi
    bc=none bg=none
    if [ -f "$D/c.caps.json" ]; then
      x=0; "$T/ebpf-precheck" --loader="$L" --caps="$D/c.caps.json" "$elf" > "$D/go.onc.json" 2>/dev/null || x=$?
      [ "$x" = "$cr" ] && [ "$(jq -cS "$j" "$D/go.onc.json")" = "$(jq -cS "$j" "$D/c.live.json")" ] && bc=same || bc=diff
    fi
    if [ -f "$D/go.caps.json" ]; then
      x=0; "$T/bml-precheck" --loader="$L" --caps="$D/go.caps.json" "$elf" > "$D/c.ongo.json" 2>/dev/null || x=$?
      [ "$x" = "$gr" ] && [ "$(jq -cS "$j" "$D/c.ongo.json")" = "$(jq -cS "$j" "$D/go.live.json")" ] && bg=same || bg=diff
    fi
    if [ -f "$D/go.onc.json" ] && [ -f "$D/c.ongo.json" ] && [ "$(jq -c .load_as "$D/go.onc.json")" != "$(jq -c .load_as "$D/c.ongo.json")" ]; then bc=diff bg=diff; fi
    kinds=$(jq -r '[.unmet[]? | .kind + (if .blocks_load then "!" else "" end)] | unique | join(",")' "$D/go.live.json" 2>/dev/null)
    echo "$n $L $a $bc $bg $(jq -r .result "$D/go.live.json" 2>/dev/null || echo ?) $gr/$cr ${kinds:--}"
  done
done
