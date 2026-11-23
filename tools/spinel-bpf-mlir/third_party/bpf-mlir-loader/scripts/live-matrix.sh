#!/bin/bash
# scripts/live-matrix.sh — E004 の live の差動の型の表 (sweep の ELF は prog type 4・map type 12 しか問わない — 表の全てを問う requirements を作る)。
# root は要らない。出力の一覧は live-diff.sh の「ELF の一覧」に渡せる (live-one.sh は *.req.txt を --requirements で渡す)。
#
#   scripts/live-matrix.sh <出力の dir>      # <dir>/list.txt に file の一覧
#
# 照合は最初の誤りで止まる (Check の規則) ので、1 つの file に誤りうる問いを 1 つだけ: (prog type, helper) の組ごと・map type ごと・
# (tracing の attach, helper) の組ごと・btf の機能の全て (btf_feature の誤りは照合を止めない)。
# prog type: 0〜34・2^32+6 (下位 32 bit で xdp)・-1。helper: 1・6・14・45・113・114・195896080・233685214 (sentinel)・0x70000001 (marshal)・
# 2^31・2^32+1。map type: 0〜35。
set -euo pipefail
D="${1:?出力の dir}"
rm -rf "$D"; mkdir -p "$D"
: > "$D/list.txt"
H='ebpf-requirements 7
schema	sha256	0000000000000000000000000000000000000000000000000000000000000000'
HS="1 6 14 45 113 114 195896080 233685214 1879048193 2147483648 4294967297"
add() { echo "$1" >> "$D/list.txt"; }
for id in $(seq 0 34) 4294967302 -1; do
  for h in $HS; do
    f="$D/prog_${id}_h$h.req.txt"
    { echo "$H"; printf 'program\tp\tt%s\t%s\n' "$id" "$id"; printf 'helper\tp\th%s\t%s\n' "$h" "$h"; } > "$f"; add "$f"
  done
done
for id in $(seq 0 35); do
  f="$D/map_$id.req.txt"
  { echo "$H"; printf 'program\tp\txdp\t6\n'; printf 'map\tm\tt%s\t%s\tu32\tu32\t1\t0\n' "$id" "$id"; } > "$f"; add "$f"
done
for at in trace_fentry:do_sys_poll trace_fexit:do_sys_poll trace_raw_tp:sched_process_fork; do
  a=${at%%:*}; t=${at#*:}
  for h in $HS; do
    f="$D/th_${a}_h$h.req.txt"
    { echo "$H"; printf 'program\tp\ttracing\t26\n'; printf 'helper\tp\th%s\t%s\n' "$h" "$h"; printf 'attach\tp\t%s\t%s\n' "$a" "$t"; } > "$f"; add "$f"
  done
done
f="$D/btf.req.txt"
{ echo "$H"; printf 'program\tp\tsocket_filter\t1\n'; for b in int ptr const array struct func func_proto func_global var datasec decl_tag; do printf 'btf\t%s\n' "$b"; done; } > "$f"; add "$f"
echo "live-matrix: $(wc -l < "$D/list.txt") file"
