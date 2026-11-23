#!/bin/bash
# scripts/attach-caller-target.sh — E038: 呼び手の先への attach を bml (test/abi/attach_caller — ASan) と cilium (test/oracle/cmd/attach-caller-oracle) で
# 同じ入力・起こし方の観測の文 ("obs" の行) で比べ (root、unshare -n の中 — 新しい netns)、C ABI の対照 ("check" の行) と変異 (attach.* — root) を
# 予測と照らす。cge と sk の観測は attachcheck の want (bpf-mlir の kernel/attachcases/cge.tsv・sk.tsv) とも照らす。子の cgroup と試験の program は
# 後に残らない。
#
#   sudo scripts/attach-caller-target.sh <出力の親> <TOOLS (asan)> <TOOLS_MUT> <attach-caller-oracle> <ebpf-compile>
set -uo pipefail
PARENT="${1:?}"; TOOLS="${2:?}"; TMUT="${3:?}"; ORA="${4:?}"; EC="${5:?}"
[ "$(id -u)" = 0 ] || { echo "attach-caller-target: root で走らせる" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$HERE/third_party/bpf-mlir"
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O/elf"
U=${SUDO_UID:-1000}
INPUTS="cge kernel/skbkinds/mlir/cge.mlir kernel/skbkinds/mlir/cge.schema.json
sk kernel/sklookup/mlir/sk.mlir kernel/sklookup/mlir/schema.json
sf kernel/skbkinds/mlir/sf.mlir kernel/skbkinds/mlir/sf.schema.json
fd kernel/skbkinds/mlir/fd.mlir kernel/skbkinds/mlir/fd.schema.json"
mapsof() { jq -c '{globals: [], maps: [.core.maps[] | {name: .symbol, kind, key: ((if .key.signed then "i" else "u" end) + (.key.bits|tostring)), value: ((if .value.signed then "i" else "u" end) + (.value.bits|tostring)), max_entries}]}' "$REPO/$1"; }
progs() { bpftool prog list 2> /dev/null | grep -cE 'name (cge|sk|sf|fd)( |$)'; }
# 予測 (E038 の H1 / H3 — 走らせる前に書いた): check の行
declare -A WANT=(
  [cge]="check cgroup_with_netns_fd 5 named|check cgroup_negative_fd 9|check netns_on_cgroup_skb 6|check program_fd_on_cgroup_skb 6"
  [sk]="check netns_with_socket_fd 5 named|check cgroup_on_sk_lookup 6"
  [sf]="check socket_with_netns_fd 5 named|check socket_negative_fd 9"
  [fd]="check socket_on_flow_dissector 6|check program_fd_on_flow_dissector 6"
)
# attachcheck の want (cge.tsv・sk.tsv) — 観測の文の形に
declare -A AC=(
  [cge]="obs none100 act=ok out=0,0|obs udp20 act=ok out=48,17|obs udp36 act=ok out=64,17|obs udp37 act=EPERM out=65,17|obs udp100 act=EPERM out=128,17"
)
declare -A MUT=([cge]=attach.cgroup_id_other [sk]=attach.netns_ino_other [fd]=attach.netns_ino_other)
before=$(progs)
bad=0
S="$O/summary.txt"
: > "$S"
while read -r id mlir schema; do
  elf="$O/elf/$id.bpf.o"
  "$EC" "$REPO/$mlir" --schema "$REPO/$schema" -o "$elf" || { echo "FAIL $id: ebpf-compile" >> "$S"; bad=1; continue; }
  sha=$(sha256sum "$REPO/$schema" | cut -d' ' -f1)
  maps=$(mapsof "$schema")
  unshare -n "$TOOLS/attach_caller" "$id" "$elf" "$sha" "$maps" > "$O/$id.bml" 2> "$O/$id.bml.err"
  unshare -n "$ORA" "$id" "$elf" > "$O/$id.go" 2> "$O/$id.go.err"
  if diff <(grep '^obs ' "$O/$id.bml") "$O/$id.go" > "$O/$id.diff"; then echo "same $id $(grep -c '^obs ' "$O/$id.bml") obs" >> "$S"; else echo "DIFF $id" >> "$S"; cat "$O/$id.diff" >> "$S"; bad=1; fi
  got=$(grep '^check ' "$O/$id.bml" | tr '\n' '|'); want="${WANT[$id]}|"
  [ "$got" = "$want" ] && echo "checks $id ok" >> "$S" || { echo "CHECKS $id got=$got want=$want" >> "$S"; bad=1; }
  if [ -n "${AC[$id]:-}" ]; then
    [ "$(grep '^obs ' "$O/$id.bml" | tr '\n' '|')" = "${AC[$id]}|" ] && echo "attachcheck-want $id ok" >> "$S" || { echo "ATTACHCHECK-WANT $id" >> "$S"; bad=1; }
  fi
  m="${MUT[$id]:-}"
  if [ -n "$m" ]; then
    BML_MUTANT=$m unshare -n "$TMUT/attach_caller" "$id" "$elf" "$sha" "$maps" > "$O/mut-$id.bml" 2> "$O/mut-$id.err"
    grep -qx 'obs attach attach=5' "$O/mut-$id.bml" && echo "mutant $m on $id ok (attach 5)" >> "$S" || { echo "MUTANT $m on $id: $(grep -m1 attach "$O/mut-$id.bml")" >> "$S"; bad=1; }
  fi
  # 変異 attach.fd_kind_skip: named の check が kernel の誤りに変わる (kind は 5 のまま)
  BML_MUTANT=attach.fd_kind_skip unshare -n "$TMUT/attach_caller" "$id" "$elf" "$sha" "$maps" > "$O/skip-$id.bml" 2> "$O/skip-$id.err"
  want_skip=$(printf '%s' "${WANT[$id]}" | sed 's/ named/ kernel/g')
  [ "$(grep '^check ' "$O/skip-$id.bml" | tr '\n' '|')" = "$want_skip|" ] && echo "mutant attach.fd_kind_skip on $id ok" >> "$S" ||
    { echo "MUTANT attach.fd_kind_skip on $id: $(grep '^check ' "$O/skip-$id.bml" | tr '\n' '|')" >> "$S"; bad=1; }
done <<< "$INPUTS"
after=$(progs)
left=$(ls -d /sys/fs/cgroup/bml-e038-* 2> /dev/null | wc -l)
[ "$before" = "$after" ] && [ "$left" = 0 ] && echo "progs same ($after) cgroups left 0" >> "$S" || { echo "LEFT progs $before→$after cgroups $left" >> "$S"; bad=1; }
chown -R "$U:$(id -g "$U")" "$PARENT"
cat "$S"
exit "$bad"
