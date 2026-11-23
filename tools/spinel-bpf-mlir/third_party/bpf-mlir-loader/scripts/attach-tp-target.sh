#!/bin/bash
# scripts/attach-tp-target.sh — E040: tracepoint の全ての CPU の attach を bml (test/abi/tp_allcpu — ASan) と Go (test/oracle/cmd/attach-tp-oracle —
# arm allcpu は bpf-mlir の livecaps.AttachTracepointAllCPUs、arm cilium は link.Tracepoint) で同じ入力・起こし方の観測の文 ("obs" の行) で比べ、
# C ABI の対照 ("check" の行) と変異 (attach.tp_* — root) を予測と照らす。試験の program を後に残さない。
#
#   sudo scripts/attach-tp-target.sh <出力の親> <TOOLS (asan)> <TOOLS_MUT> <attach-tp-oracle> <ebpf-compile>
set -uo pipefail
PARENT="${1:?}"; TOOLS="${2:?}"; TMUT="${3:?}"; ORA="${4:?}"; EC="${5:?}"
[ "$(id -u)" = 0 ] || { echo "attach-tp-target: root で走らせる" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$HERE/third_party/bpf-mlir"
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O/elf"
U=${SUDO_UID:-1000}
mapsof() { jq -c '{globals: [], maps: [.core.maps[] | {name: .symbol, kind, key: ((if .key.signed then "i" else "u" end) + (.key.bits|tostring)), value: ((if .value.signed then "i" else "u" end) + (.value.bits|tostring)), max_entries}]}' "$REPO/$1"; }
progs() { bpftool prog list 2> /dev/null | grep -cE 'name (tpw|tp|sf)( |$)'; }
# 予測 (E040 の H2〜H4 と追補 — 走らせる前に書いた)。ncpu は online の CPU の数 (attach の間は +ncpu の perf の event)
NC=$(nproc --all); X=$((NC - 1))
declare -A OBS=(
  [tpw]="obs none-each out0=0 out1=0 out2=7*out0 perf=+0,+0|obs allcpu-each out0=ncpu*N out1=1 out2=7*out0 perf=+ncpu,+0|obs allcpu-any out0=1*N out1=1 out2=7*out0 perf=+ncpu,+0|obs allcpu-other out0=0 out1=0 out2=7*out0 perf=+ncpu,+0"
  [tp]="obs none-each out0=0 out1=0 perf=+0,+0|obs allcpu-each out0=ncpu*N out1=110 perf=+ncpu,+0"
)
declare -A CHECK=(
  [tpw]="check second_attach_same_program 5 named|check second_attach_perf +0|check unknown_flags 9|check no_such_program 6"
  [tp]=""
)
# 変異の予測: tp_cpu0_only は CPU 0 だけ (cilium の arm と同じ — 固定なしの any は CPU に依るので比べない)、tp_name_other は attach が 5、
# tp_keep_extra は detach の後に ncpu − 1 の perf の event が残る
declare -A CPU0=(
  [tpw]="obs none-each out0=0 out1=0 out2=7*out0 perf=+0,+0|obs allcpu-each out0=1*N out1=1 out2=7*out0 perf=+1,+0|obs allcpu-other out0=0 out1=0 out2=7*out0 perf=+1,+0"
  [tp]="obs none-each out0=0 out1=0 perf=+0,+0|obs allcpu-each out0=ncpu*N out1=110 perf=+1,+0"
)
declare -A NAME=(
  [tpw]="obs none-each out0=0 out1=0 out2=7*out0 perf=+0,+0|obs allcpu-each attach=5|obs allcpu-any attach=5|obs allcpu-other attach=5"
  [tp]="obs none-each out0=0 out1=0 perf=+0,+0|obs allcpu-each attach=5"
)
declare -A KEEP=(
  [tpw]="obs none-each out0=0 out1=0 out2=7*out0 perf=+0,+0|obs allcpu-each out0=ncpu*N out1=1 out2=7*out0 perf=+ncpu,+$X|obs allcpu-any out0=1*N out1=1 out2=7*out0 perf=+ncpu,+$X|obs allcpu-other out0=0 out1=0 out2=7*out0 perf=+ncpu,+$X"
  [tp]="obs none-each out0=0 out1=0 perf=+0,+0|obs allcpu-each out0=ncpu*N out1=110 perf=+ncpu,+$X"
)
before=$(progs)
bad=0
S="$O/summary.txt"
: > "$S"
lines() { grep "^$1 " "$2" | grep -v "${3:-^$}" | tr '\n' '|'; }
expect() { # <名前> <得た> <予測>
  [ "$2" = "$3|" ] && echo "$1 ok" >> "$S" || { echo "FAIL $1 got=$2 want=$3" >> "$S"; bad=1; }
}
for id in tpw tp; do
  if [ "$id" = tpw ]; then mlir=kernel/tracepoint/mlir/g14_tpw.mlir; schema=kernel/tracepoint/mlir/g14_tpw.schema.json; else mlir=kernel/tracepoint/mlir/tp.mlir; schema=kernel/tracepoint/mlir/schema.json; fi
  elf="$O/elf/$id.bpf.o"
  "$EC" "$REPO/$mlir" --schema "$REPO/$schema" -o "$elf" || { echo "FAIL $id: ebpf-compile" >> "$S"; bad=1; continue; }
  sha=$(sha256sum "$REPO/$schema" | cut -d' ' -f1)
  maps=$(mapsof "$schema")
  unshare -n "$TOOLS/tp_allcpu" "$id" "$elf" "$sha" "$maps" > "$O/$id.bml" 2> "$O/$id.bml.err"
  unshare -n "$ORA" allcpu "$id" "$elf" > "$O/$id.go" 2> "$O/$id.go.err"
  unshare -n "$ORA" cilium "$id" "$elf" > "$O/$id.cilium" 2> "$O/$id.cilium.err"
  if diff <(grep '^obs ' "$O/$id.bml") "$O/$id.go" > "$O/$id.diff"; then echo "same $id $(grep -c '^obs ' "$O/$id.bml") obs (bml = livecaps.AttachTracepointAllCPUs)" >> "$S"; else echo "DIFF $id" >> "$S"; cat "$O/$id.diff" >> "$S"; bad=1; fi
  expect "obs-want $id" "$(lines obs "$O/$id.bml")" "${OBS[$id]}"
  [ -z "${CHECK[$id]}" ] || expect "checks $id" "$(lines check "$O/$id.bml")" "${CHECK[$id]}"
  BML_MUTANT=attach.tp_cpu0_only unshare -n "$TMUT/tp_allcpu" "$id" "$elf" "$sha" "$maps" > "$O/cpu0-$id.bml" 2> "$O/cpu0-$id.err"
  expect "mutant tp_cpu0_only $id" "$(lines obs "$O/cpu0-$id.bml" 'allcpu-any')" "${CPU0[$id]}"
  expect "cilium-arm = tp_cpu0_only $id" "$(lines obs "$O/$id.cilium" 'allcpu-any')" "${CPU0[$id]}"
  BML_MUTANT=attach.tp_name_other unshare -n "$TMUT/tp_allcpu" "$id" "$elf" "$sha" "$maps" > "$O/name-$id.bml" 2> "$O/name-$id.err"
  expect "mutant tp_name_other $id" "$(lines obs "$O/name-$id.bml")" "${NAME[$id]}"
  BML_MUTANT=attach.tp_keep_extra unshare -n "$TMUT/tp_allcpu" "$id" "$elf" "$sha" "$maps" > "$O/keep-$id.bml" 2> "$O/keep-$id.err"
  expect "mutant tp_keep_extra $id" "$(lines obs "$O/keep-$id.bml")" "${KEEP[$id]}"
done
# 無い event (bpf-mlir E419 の nosuch — 照合は attach_target_unknown で load する): 名指しの OTHER で perf の event を残さない
NS="$REPO/docs/experiments/results/E419/nosuch.bpf.o"
nsha=$("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -p .ebpf_requirements "$NS" | grep -o 'sha256\.[0-9a-f]\{64\}' | head -1 | cut -c8-)
nmaps='{"globals":[],"maps":[{"name":"cfg","kind":"array","key":"u32","value":"u32","max_entries":1},{"name":"out","kind":"array","key":"u32","value":"u32","max_entries":1}]}'
unshare -n "$TOOLS/tp_allcpu" nosuch "$NS" "$nsha" "$nmaps" > "$O/nosuch.bml" 2> "$O/nosuch.err"
expect "checks nosuch" "$(lines check "$O/nosuch.bml")" "check missing_event 5 named|check missing_event_perf +0"
# 取り違え: socket_filter の program (E038 の sf) に bml_attach_tracepoint は STATE
"$EC" "$REPO/kernel/skbkinds/mlir/sf.mlir" --schema "$REPO/kernel/skbkinds/mlir/sf.schema.json" -o "$O/elf/sf.bpf.o"
unshare -n "$TOOLS/tp_allcpu" kind "$O/elf/sf.bpf.o" "$(sha256sum "$REPO/kernel/skbkinds/mlir/sf.schema.json" | cut -d' ' -f1)" "$(mapsof kernel/skbkinds/mlir/sf.schema.json)" sf > "$O/kind.bml" 2> "$O/kind.err"
expect "checks kind" "$(lines check "$O/kind.bml")" "check tracepoint_on_other_kind 6"
after=$(progs)
[ "$before" = "$after" ] && echo "progs same ($after)" >> "$S" || { echo "LEFT progs $before→$after" >> "$S"; bad=1; }
chown -R "$U:$(id -g "$U")" "$PARENT"
cat "$S"
exit "$bad"
